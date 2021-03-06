require_relative 'iam_helper'

describe MozillaIAM do
  before do
    NotificationEmailer.enable
    SiteSetting.queue_jobs = false
  end

  context 'new post in restricted category' do

    let(:poster) { Fabricate(:user_with_secondary_email) }
    let(:user) { Fabricate(:user_with_secondary_email) }
    let(:group) { Fabricate(:group, users: [user]) }
    let(:category) { Fabricate(:private_category, group: group) }
    let(:topic) { Fabricate(:topic, category: category, user: poster) }
    let(:post) { Fabricate(:post, topic: topic, user: poster) }
    let(:reply) { Fabricate(:post, topic: topic, user: poster) }
    let(:uid) { create_uid(user.username) }
    let(:last_refresh) { Time.now - 16.minutes }

    before do
      MozillaIAM::GroupMapping.new(iam_group_name: 'iam_group',
                                   group: group).save!
      TopicUser.change(user.id, topic.id, notification_level: TopicUser.notification_levels[:watching])
      user.custom_fields['mozilla_iam_uid'] = uid
      user.custom_fields['mozilla_iam_last_refresh'] = last_refresh
      user.save_custom_fields
    end

    context 'when user in correct IAM group' do
      before { stub_apis_profile_request(uid, groups: ['iam_group']) }

      it 'refreshes the user profile' do
        PostAlerter.post_created(reply)
        user.clear_custom_fields
        expect(Time.parse(user.custom_fields['mozilla_iam_last_refresh'])).to be_within(5.seconds).of Time.now
      end

      it 'alerts the user' do
        expect {
          PostAlerter.post_created(reply)
        }.to change(user.notifications, :count).by 1
      end

      it 'emails the user' do
        PostAlerter.post_created(reply)
        expect(EmailLog.where(user: user, post: reply, email_type: 'user_posted').count).to eq(1)
      end

      it 'sends the user a mailing list email' do
        user.user_option.update(mailing_list_mode: true, mailing_list_mode_frequency: 1)
        Jobs::NotifyMailingListSubscribers.new.execute(post_id: reply.id)
        expect(EmailLog.where(user: user, post: reply, email_type: 'mailing_list').count).to eq(1)
      end
    end

    context 'when user removed from IAM group' do
      before { stub_apis_profile_request(uid, groups: []) }

      it 'refreshes the user profile' do
        PostAlerter.post_created(reply)
        user.clear_custom_fields
        expect(Time.parse(user.custom_fields['mozilla_iam_last_refresh'])).to be_within(5.seconds).of Time.now
      end

      it 'does not alert the user' do
        expect {
          PostAlerter.post_created(reply)
        }.to_not change(user.notifications, :count)
      end

      it 'does not email the user' do
        PostAlerter.post_created(reply)
        expect(EmailLog.where(user: user, post: reply, email_type: 'user_posted').count).to eq(0)
      end

      it 'does not send the user a mailing list email' do
        user.user_option.update(mailing_list_mode: true, mailing_list_mode_frequency: 1)
        Jobs::NotifyMailingListSubscribers.new.execute(post_id: reply.id)
        expect(EmailLog.where(user: user, post: reply, email_type: 'mailing_list').count).to eq(0)
      end
    end
  end

  context 'new private message' do
    let(:author) { Fabricate(:user_with_secondary_email) }
    let(:user) { Fabricate(:user_with_secondary_email) }
    let(:post) do
      PostCreator.create(author, title: 'private message test',
                                 raw: 'this is my private message',
                                 archetype: Archetype.private_message,
                                 target_usernames: user.username)
    end
    let(:uid) { create_uid(user.username) }
    let(:last_refresh) { Time.now - 16.minutes }

    before do
      TopicUser.change(user.id, post.topic.id, notification_level: TopicUser.notification_levels[:watching])
      user.custom_fields['mozilla_iam_uid'] = uid
      user.custom_fields['mozilla_iam_last_refresh'] = last_refresh
      user.save_custom_fields
    end

    it 'does not refresh the user profile' do
      user.clear_custom_fields
      expect(Time.parse(user.custom_fields['mozilla_iam_last_refresh'])).to be_within(5.seconds).of last_refresh
    end

    it 'alerts the user' do
      expect(user.notifications.count).to eq(1)
    end

    it 'emails the user' do
      expect(EmailLog.where(user: user, post: post, email_type: 'user_private_message').count).to eq(1)
    end
  end

end
